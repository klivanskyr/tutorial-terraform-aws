from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.serializers import TokenRefreshSerializer

from .LoginView import _set_auth_cookies

ACCESS_MAX_AGE  = 60 * 60 * 24      # 1 day
REFRESH_MAX_AGE = 60 * 60 * 24 * 7  # 7 days


class TokenRefreshView(APIView):
    """
    POST /api/auth/refresh/

    Reads the refresh_token cookie, validates it, and issues a new access token.
    Because ROTATE_REFRESH_TOKENS = True in settings, the old refresh token is
    blacklisted and a brand-new refresh token is issued alongside the new access
    token. This gives active sessions a sliding 7-day window.

    No request body needed — everything comes from the HttpOnly cookie.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        refresh_token = request.COOKIES.get('refresh_token')
        if not refresh_token:
            return Response(
                {'error': 'No refresh token cookie'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        serializer = TokenRefreshSerializer(data={'refresh': refresh_token})
        try:
            serializer.is_valid(raise_exception=True)
        except TokenError as e:
            raise InvalidToken(e.args[0])

        response = Response({'message': 'Token refreshed'})
        # serializer always returns 'access'; returns 'refresh' too when rotation is on
        _set_auth_cookies(
            response,
            serializer.validated_data['access'],
            serializer.validated_data.get('refresh', refresh_token),
        )
        return response
